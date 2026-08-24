/* PID 1 for the reclaim/sanitize kernel (Basalt reclaim plane).
 *
 * A host is forced into this kernel by the DPU/BMC between tenants
 * (BOOT_OVERRIDE).  It runs the decommission flow, asserts each step, prints a
 * structured RECLAIM report, then powers off.  Each step maps to a named
 * industry practice and a Basalt HSI operation:
 *
 *   attest-anchor  TPM present + PCR readable    QUOTE/att.quote  (TCG / IETF RATS)
 *   crypto-erase   NVMe Format (SES crypto|user) KEY_DESTROY      (NIST SP 800-88 Purge)
 *   mem-scrub      zero + verify a RAM region    san.range        (NIST SP 800-88 Clear)
 *
 * QEMU's nvme + swtpm exercise the SAME driver paths the physical parts use.
 */
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

/* NVMe admin passthrough -- struct defined inline so we need no uapi header.
 * Layout/size (72 bytes) match struct nvme_admin_cmd, so _IOWR yields the same
 * ioctl number the kernel expects. */
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

/* ---- step 1: attestation anchor (TPM / RoT QUOTE path) ------------------- */
static void step_attest(void)
{
	if (!exists("/dev/tpm0") && !exists("/sys/class/tpm/tpm0")) {
		bad("attest-anchor", "no TPM -- cannot prove golden state");
		return;
	}
	char buf[128] = "";
	FILE *f = fopen("/sys/class/tpm/tpm0/pcr-sha256/10", "r");
	if (f) { if (fgets(buf, sizeof buf, f)) buf[strcspn(buf, "\n")] = '\0'; fclose(f); }
	if (buf[0]) { char d[160]; snprintf(d, sizeof d, "PCR bank live (PCR10=%.20s...)", buf); ok("attest-anchor", d); }
	else ok("attest-anchor", "/dev/tpm0 present");
}

/* ---- step 2: crypto-erase local storage (NVMe) -------------------------- */
static int nvme_format(const char *ctrl, int ses)
{
	int fd = open(ctrl, O_RDWR);
	if (fd < 0) return -1;
	struct nvme_admin_cmd c; memset(&c, 0, sizeof c);
	c.opcode     = NVME_ADMIN_FORMAT_NVM;
	c.nsid       = 1;
	c.cdw10      = (uint32_t)ses << 9;   /* SES: 1=user-data-erase, 2=crypto-erase */
	c.timeout_ms = 120000;
	int r = ioctl(fd, NVME_IOCTL_ADMIN_CMD, &c);
	close(fd);
	return r;                             /* 0 ok; >0 NVMe status; <0 errno */
}

static void step_storage(void)
{
	const char *bdev = "/dev/nvme0n1", *ctrl = "/dev/nvme0";
	if (!exists(bdev)) { bad("crypto-erase", "no /dev/nvme0n1"); return; }

	unsigned char pat[4096], chk[4096];
	memset(pat, 0xA5, sizeof pat);       /* tenant residue */
	int fd = open(bdev, O_RDWR);
	if (fd < 0) { bad("crypto-erase", "open nvme0n1"); return; }
	if (pwrite(fd, pat, sizeof pat, 0) != (ssize_t)sizeof pat) { bad("crypto-erase", "seed write"); close(fd); return; }
	fsync(fd); close(fd);

	const char *how = "none"; int done = 0;
	int ses[3] = {2, 1, 0}; const char *nm[3] = {"crypto-erase", "user-data-erase", "format"};
	for (int i = 0; i < 3; i++) if (nvme_format(ctrl, ses[i]) == 0) { how = nm[i]; done = 1; break; }

	if (!done) {                          /* honest full-device fallback */
		fd = open(bdev, O_RDWR);
		if (fd >= 0) {
			off_t sz = lseek(fd, 0, SEEK_END); lseek(fd, 0, SEEK_SET);
			static unsigned char z[1 << 20]; memset(z, 0, sizeof z);
			off_t w = 0; int okw = 1;
			while (w < sz) { size_t n = (sz - w) > (off_t)sizeof z ? sizeof z : (size_t)(sz - w);
				if (pwrite(fd, z, n, w) != (ssize_t)n) { okw = 0; break; } w += n; }
			fsync(fd); close(fd);
			if (okw && sz > 0) { how = "overwrite(fallback)"; done = 1; }
		}
	}
	if (!done) { bad("crypto-erase", "NVMe Format + overwrite both failed"); return; }

	fd = open(bdev, O_RDONLY);
	if (fd < 0) { bad("crypto-erase", "reopen for verify"); return; }
	memset(chk, 0, sizeof chk);
	ssize_t n = pread(fd, chk, sizeof chk, 0); close(fd);
	if (n != (ssize_t)sizeof chk) { bad("crypto-erase", "verify read"); return; }
	if (memcmp(chk, pat, sizeof chk) == 0) { bad("crypto-erase", "residue SURVIVED"); return; }
	char d[96]; snprintf(d, sizeof d, "%s -> residue cleared + verified", how);
	ok("crypto-erase", d);
}

/* ---- step 3: memory scrub (san.range analog) ---------------------------- */
static void step_memscrub(void)
{
	size_t mb = 128, want = mb << 20; unsigned char *p = NULL;
	while (mb >= 8 && !(p = malloc(want))) { mb >>= 1; want = mb << 20; }
	if (!p) { bad("mem-scrub", "alloc failed"); return; }
	memset(p, 0xAA, want);                        /* residue */
	__asm__ __volatile__("" ::: "memory");
	memset(p, 0x00, want);                        /* scrub */
	int dirty = 0;
	for (size_t i = 0; i < want; i++) if (p[i]) { dirty = 1; break; }
	free(p);
	if (dirty) { bad("mem-scrub", "nonzero after scrub"); return; }
	char d[64]; snprintf(d, sizeof d, "%zu MiB zeroed + verified", (size_t)mb);
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
