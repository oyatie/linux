/* PID 1 for the LUO handover test.  One QEMU boot proves it:
 *   kernel A -> preserve a memfd via LUO -> kexec (in-place) -> kernel B
 *   -> restore the memfd and verify the bytes survived.
 * Stage is carried on the kexec cmdline (luo_stage=2); the preserved state
 * itself rides KHO, not disk. */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
#include <linux/reboot.h>

static int run(char *const argv[])
{
	pid_t p = fork();
	if (p == 0) { execv(argv[0], argv); _exit(127); }
	int st = 0; waitpid(p, &st, 0);
	return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

int main(void)
{
	char cl[2048] = "";
	int fd;

	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("debugfs", "/sys/kernel/debug", "debugfs", 0, NULL);
	mount("securityfs", "/sys/kernel/security", "securityfs", 0, NULL);
	mount("tmpfs", "/tmp", "tmpfs", 0, NULL);
	mount("/dev/vda", "/boot", "vfat", MS_RDONLY, NULL);

	fd = open("/proc/cmdline", O_RDONLY);
	if (fd >= 0) { read(fd, cl, sizeof(cl) - 1); close(fd); }

	if (strstr(cl, "luo_stage=2")) {
		char *a[] = {"/luo_kexec_simple", "--stage", "2", NULL};
		printf("\nLUO-TEST: post-kexec, running stage 2\n");
		printf(run(a) == 0 ? "LUO-TEST: RESULT PASS\n" : "LUO-TEST: RESULT FAIL\n");
		sync(); reboot(RB_POWER_OFF); return 0;
	}

	/* Stage 1: preserve, then kexec into the (signed) next kernel. */
	char *a[] = {"/luo_kexec_simple", "--stage", "1", NULL};
	printf("\nLUO-TEST: pre-kexec, running stage 1 (preserve memfd)\n");
	if (run(a) != 0) { printf("LUO-TEST: RESULT FAIL (stage 1)\n"); sync(); reboot(RB_POWER_OFF); }

	int kfd = open("/boot/bzImage", O_RDONLY);
	int ifd = open("/boot/initramfs", O_RDONLY);
	const char *kcl = "console=ttyS0 liveupdate=on luo_stage=2 rdinit=/init";
	printf("LUO-TEST: kexec_file_load(signed next kernel) + jump\n");
	long r = syscall(SYS_kexec_file_load, kfd, ifd,
			 (unsigned long)(strlen(kcl) + 1), kcl, 0UL);
	if (r < 0) { perror("LUO-TEST: kexec_file_load"); printf("LUO-TEST: RESULT FAIL (kexec refused)\n");
		     sync(); reboot(RB_POWER_OFF); return 0; }
	reboot(LINUX_REBOOT_CMD_KEXEC);
	printf("LUO-TEST: RESULT FAIL (kexec jump returned)\n");
	sync(); reboot(RB_POWER_OFF);
	return 0;
}
