/* PID 1 for the reclaim/sanitize kernel (Basalt reclaim plane).
 *
 * A host is forced into this kernel by the DPU/BMC between tenants
 * (BOOT_OVERRIDE).  It runs the decommission flow, asserts each step, prints a
 * structured RECLAIM report, then powers off.  Each step maps to a named
 * industry practice and a Basalt HSI operation:
 *
 *   attest-anchor  TPM present (anchor)          QUOTE is done by the RoT (TCG/RATS)
 *   crypto-erase   NVMe Format SES=crypto|user   KEY_DESTROY  (NIST SP 800-88 Purge)
 *   mem-scrub      zero + verify free RAM        san.range    (NIST SP 800-88 Clear)
 *
 * QEMU's nvme + swtpm exercise the SAME driver paths the physical parts use.
 * Safety note: crypto-erase enumerates EVERY NVMe namespace and verifies the
 * wipe at several offsets -- a box is only "re-poolable" if all of them clear.
 */
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

/* NVMe admin passthrough -- struct defined inline (72 bytes, matches the UAPI
 * so _IOWR yields the kernel's ioctl number). */
struct nvme_admin_cmd {
	uint8_t  opcode;  uint8_t  flags;  uint16_t rsvd1;
	uint32_t nsid;    uint32_t cdw2;   uint32_t cdw3;
	uint64_t metadata; uint64_t addr;
	uint32_t metadata_len; uint32_t data_len;
	uint32_t cdw10; uint32_t cdw11; uint32_t cdw12;
	uint32_t cdw13; uint32_t cdw14; uint32_t cdw15;
	uint32_t timeout_ms; uint32_t result;
};
#define NVME_IOCTL_ADMIN_CMD  _IOWR('N', 0x41, struct nvme_admin_cmd)
#define NVME_ADMIN_FORMAT_NVM 0x80

static int failures;
static void ok(const char *w, const char *d){ printf("RECLAIM ok       %-14s %s\n", w, d); }
static void bad(const char *w, const char *d){ printf("RECLAIM FAIL     %-14s %s\n", w, d); failures++; }
static int  exists(const char *p){ struct stat st; return stat(p, &st) == 0; }

/* ---- step 1: attestation ANCHOR (presence only; the RoT does the quote) --- */
static void step_attest(void)
{
	if (!exists("/dev/tpm0") && !exists("/sys/class/tpm/tpm0")) {
		bad("attest-anchor", "no TPM -- cannot anchor a quote");
		return;
	}
	char buf[128] = "";
	FILE *f = fopen("/sys/class/tpm/tpm0/pcr-sha256/10", "r");
	if (f) { if (fgets(buf, sizeof buf, f)) buf[strcspn(buf, "\n")] = '\0'; fclose(f); }
	if (buf[0]) { char d[160]; snprintf(d, sizeof d, "PCR bank live (%.16s...); quote=RoT", buf); ok("attest-anchor", d); }
	else ok("attest-anchor", "/dev/tpm0 present; quote=RoT");
}

/* ---- NVMe Format on <ctrl> nsid <nsid>, secure-erase setting <ses> -------- */
static int nvme_format(const char *ctrl, uint32_t nsid, int ses)
{
	int fd = open(ctrl, O_RDWR);
	if (fd < 0) return -1;
	struct nvme_admin_cmd c; memset(&c, 0, sizeof c);
	c.opcode = NVME_ADMIN_FORMAT_NVM; c.nsid = nsid;
	c.cdw10 = (uint32_t)ses << 9;     /* SES: 1=user-data-erase, 2=crypto-erase */
	c.timeout_ms = 120000;
	int r = ioctl(fd, NVME_IOCTL_ADMIN_CMD, &c); close(fd);
	return r;                          /* 0 ok; >0 NVMe status; <0 errno */
}

/* seed + erase + verify one namespace at three offsets.  Returns 0 on a
 * verified wipe, -1 otherwise.  SES=0 (non-erasing format) is NOT accepted as
 * a crypto-erase; the read-back verify is the real guarantee either way. */
static int wipe_ns(const char *bdev, const char *ctrl, uint32_t nsid, char *how, size_t hlen)
{
	int fd = open(bdev, O_RDWR);
	if (fd < 0) return -1;
	off_t sz = lseek(fd, 0, SEEK_END);
	if (sz < 4096) sz = 4096;
	off_t off[3] = { 0, (sz / 2) & ~4095L, (sz - 4096) & ~4095L };
	unsigned char pat[4096], chk[4096];
	memset(pat, 0xA5, sizeof pat);
	for (int i = 0; i < 3; i++) (void)pwrite(fd, pat, sizeof pat, off[i]);
	fsync(fd); close(fd);

	int done = 0;
	int ses[2] = {2, 1}; const char *nm[2] = {"crypto-erase", "user-data-erase"};
	for (int i = 0; i < 2 && !done; i++)
		if (nvme_format(ctrl, nsid, ses[i]) == 0) { snprintf(how, hlen, "%s", nm[i]); done = 1; }
	if (!done) {                        /* honest full-device zero overwrite */
		fd = open(bdev, O_RDWR);
		if (fd >= 0) {
			static unsigned char z[1 << 20]; memset(z, 0, sizeof z);
			off_t w = 0; int okw = 1;
			while (w < sz) { size_t n = (sz - w) > (off_t)sizeof z ? sizeof z : (size_t)(sz - w);
				if (pwrite(fd, z, n, w) != (ssize_t)n) { okw = 0; break; } w += n; }
			fsync(fd); close(fd);
			if (okw) { snprintf(how, hlen, "overwrite"); done = 1; }
		}
	}
	if (!done) return -1;

	fd = open(bdev, O_RDONLY);
	if (fd < 0) return -1;
	for (int i = 0; i < 3; i++) {
		memset(chk, 0, sizeof chk);
		if (pread(fd, chk, sizeof chk, off[i]) != (ssize_t)sizeof chk) { close(fd); return -1; }
		if (memcmp(chk, pat, sizeof chk) == 0) { close(fd); return -1; }  /* residue survived */
	}
	close(fd);
	return 0;
}

/* ---- step 2: crypto-erase EVERY local NVMe namespace ---------------------- */
static void step_storage(void)
{
	DIR *d = opendir("/dev");
	if (!d) { bad("crypto-erase", "cannot scan /dev"); return; }
	struct dirent *e; int found = 0, wiped = 0; char last[320] = "";
	while ((e = readdir(d))) {
		const char *n = e->d_name;
		if (strncmp(n, "nvme", 4)) continue;
		const char *p = n + 4;
		if (!isdigit((unsigned char)*p)) continue;
		char ctrl[64]; int ci = 0;
		ctrl[ci++] = 'n'; ctrl[ci++] = 'v'; ctrl[ci++] = 'm'; ctrl[ci++] = 'e';
		while (isdigit((unsigned char)*p) && ci < 60) ctrl[ci++] = *p++;
		ctrl[ci] = '\0';
		if (*p != 'n') continue;                 /* controller char dev, skip */
		p++;
		if (!isdigit((unsigned char)*p)) continue;
		uint32_t nsid = (uint32_t)strtoul(p, (char **)&p, 10);
		if (*p != '\0') continue;                /* a partition (…p1), skip */
		found++;
		char bdev[288], cpath[288], how[32] = "?";
		snprintf(bdev, sizeof bdev, "/dev/%s", n);
		snprintf(cpath, sizeof cpath, "/dev/%s", ctrl);
		if (wipe_ns(bdev, cpath, nsid, how, sizeof how) == 0) {
			wiped++; snprintf(last, sizeof last, "%s: %s", n, how);
		} else {
			char m[320]; snprintf(m, sizeof m, "%s NOT erased -- residue may survive", n);
			bad("crypto-erase", m);
		}
	}
	closedir(d);
	if (found == 0) { bad("crypto-erase", "no NVMe namespaces found"); return; }
	if (wiped == found) {
		char m[400]; snprintf(m, sizeof m, "%d/%d namespaces erased+verified (%s)", wiped, found, last);
		ok("crypto-erase", m);
	}
	/* any per-namespace failure already recorded a bad() above */
}

/* ---- step 3: best-effort free-RAM scrub (RoT san.range does all of DRAM) --
 * Scrub a bounded fraction of MemAvailable, holding distinct pages but leaving
 * headroom so PID 1 is not OOM-killed; the full physical-RAM scrub is the RoT
 * san.range engine and the cold boot after poweroff. */
static void step_memscrub(void)
{
	long avail_kb = 0;
	FILE *f = fopen("/proc/meminfo", "r");
	if (f) { char l[256]; while (fgets(l, sizeof l, f)) if (sscanf(l, "MemAvailable: %ld kB", &avail_kb) == 1) break; fclose(f); }
	size_t cap_mib = avail_kb > 0 ? (size_t)(avail_kb / 1024) * 62 / 100 : 128;
	if (cap_mib < 32) cap_mib = 32;

	enum { CHUNK = 32u << 20 };
	size_t want = cap_mib / 32; if (!want) want = 1;
	unsigned char **blk = calloc(want, sizeof *blk);
	if (!blk) { bad("mem-scrub", "bookkeeping alloc failed"); return; }
	size_t nc = 0, mib = 0;
	for (size_t i = 0; i < want; i++) {
		unsigned char *p = malloc(CHUNK);
		if (!p) break;
		memset(p, 0xAA, CHUNK);                 /* dirty (defeat INIT_ON_ALLOC) */
		blk[nc++] = p; mib += CHUNK >> 20;
	}
	if (nc == 0) { free(blk); bad("mem-scrub", "alloc failed"); return; }
	int dirty = 0;
	for (size_t i = 0; i < nc; i++) {
		memset(blk[i], 0x00, CHUNK);            /* scrub */
		for (size_t j = 0; j < CHUNK; j += 4096) if (blk[i][j]) { dirty = 1; break; }
	}
	for (size_t i = 0; i < nc; i++) free(blk[i]);
	free(blk);
	if (dirty) { bad("mem-scrub", "nonzero after scrub"); return; }
	char d[96]; snprintf(d, sizeof d, "%zu MiB free RAM zeroed+verified (rest: poweroff/RoT)", mib);
	ok("mem-scrub", d);
}

int main(void)
{
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	int c = open("/dev/console", O_RDWR);
	if (c >= 0) { dup2(c, 0); dup2(c, 1); dup2(c, 2); if (c > 2) close(c); }
	setvbuf(stdout, NULL, _IONBF, 0);

	printf("\nRECLAIM init: between-tenant sanitize (Basalt reclaim plane)\n");
	printf("RECLAIM init: forced boot target -- BOOT_OVERRIDE(reclaim)\n\n");

	step_attest();
	step_storage();
	step_memscrub();

	printf("\nRECLAIM: RESULT %s\n", failures ? "FAIL" : "PASS");
	printf("RECLAIM: box %s\n", failures ? "QUARANTINED for inspection" : "eligible for re-pooling");

	sync(); sleep(1);
	reboot(RB_POWER_OFF);
	for (;;) pause();
	return 0;
}
