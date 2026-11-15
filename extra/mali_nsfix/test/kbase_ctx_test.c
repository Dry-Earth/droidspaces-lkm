/*
 * kbase_ctx_test - create a Mali GPU context from inside a PID namespace.
 *
 * kbase_create_context() looks up task_struct->tgid (an initial-namespace value)
 * with find_get_pid(), which searches the caller's active namespace. Inside a
 * container the two disagree, the lookup fails, kbase_create_context() returns
 * NULL and kbase_file_create_kctx() turns that into -ENOMEM. dmesg shows
 *
 *     mali <addr>.mali: Failed to get pid pointer for <comm>/<pid>
 *
 * With mali_nsfix loaded the lookup is redirected to the caller's own group
 * leader and this program reports a created context.
 *
 * ioctl numbers are the ones this driver build actually accepts. Note that
 * VERSION_CHECK is 0xc0048034 here, not the 0xc0048000 that _IOWR(0x80, 0, 4)
 * would give; the nr-0 form returns -EPERM because the driver keeps that slot
 * for the reserved variant.
 *
 * Build: gcc -O2 -static -o kbase_ctx_test kbase_ctx_test.c
 */
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <stdint.h>

struct kbase_ioctl_version_check {
	uint16_t major;
	uint16_t minor;
};

#define KBASE_IOCTL_VERSION_CHECK 0xC0048034UL
#define KBASE_IOCTL_SET_FLAGS     0x40048001UL

int main(void)
{
	struct kbase_ioctl_version_check ver = { 1, 0 };
	uint32_t flags = 0;
	int fd, ret;

	fd = open("/dev/mali0", O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		printf("open(/dev/mali0): %s\n", strerror(errno));
		return 2;
	}

	errno = 0;
	ret = ioctl(fd, KBASE_IOCTL_VERSION_CHECK, &ver);
	printf("VERSION_CHECK -> %d", ret);
	if (ret < 0)
		printf(" errno=%d (%s)\n", errno, strerror(errno));
	else
		printf(" driver API %u.%u\n", ver.major, ver.minor);
	if (ret < 0)
		goto out;

	/*
	 * SET_FLAGS is what reaches kbase_create_context() on this build: the
	 * version check leaves setup_state at NEED_CTX and the context is created
	 * here. Without the pid fix this returns -ENOMEM.
	 */
	errno = 0;
	ret = ioctl(fd, KBASE_IOCTL_SET_FLAGS, &flags);
	printf("SET_FLAGS     -> %d", ret);
	if (ret < 0)
		printf(" errno=%d (%s)\n", errno, strerror(errno));
	else
		printf(" GPU context created\n");
out:
	close(fd);
	return ret < 0 ? 1 : 0;
}