#define _GNU_SOURCE
/* Test-only syscall interposition. Never linked into the service or runtime
 * image. A control file arms an exact filesystem boundary without sleeps in
 * production code. Its first line is space, io, or kill; second is a path
 * substring. Only directory syncs are intercepted. */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int fsync(int fd) {
    const char *control = getenv("NZBUNNY_TEST_FAULT_FILE");
    if (control) {
        int config = open(control, O_RDONLY | O_CLOEXEC);
        if (config >= 0) {
            char command[PATH_MAX + 32];
            ssize_t size = read(config, command, sizeof(command) - 1);
            close(config);
            if (size > 0) {
                command[size] = 0;
                char *match = strchr(command, '\n');
                if (match) {
                    *match++ = 0;
                    match[strcspn(match, "\r\n")] = 0;
                    char link[64], path[PATH_MAX];
                    struct stat st;
                    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
                    ssize_t length = readlink(link, path, sizeof(path) - 1);
                    if (length > 0 && fstat(fd, &st) == 0 && S_ISDIR(st.st_mode)) {
                        path[length] = 0;
                        if (*match && strstr(path, match)) {
                            if (!strcmp(command, "kill")) {
                                unlink(control); /* one-shot, including across restart */
                                kill(getpid(), SIGKILL);
                                _exit(137);
                            }
                            if (!strcmp(command, "space") || !strcmp(command, "io")) {
                                errno = !strcmp(command, "space") ? ENOSPC : EIO;
                                return -1;
                            }
                        }
                    }
                }
            }
        }
    }
    int (*real_fsync)(int) = dlsym(RTLD_NEXT, "fsync");
    return real_fsync(fd);
}
