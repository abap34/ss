#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

ssize_t write(int fd, const void *buffer, size_t length) {
    ssize_t (*original_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
    static unsigned int edit_responses;
    ssize_t written = original_write(fd, buffer, length);
    int saved_errno = errno;
    const char *barrier = getenv("SS_TEST_EDIT_RESPONSE_BARRIER");
    if (barrier == NULL || fd != STDOUT_FILENO || written != (ssize_t)length ||
        memmem(buffer, length, "\"workspaceEdit\"", sizeof("\"workspaceEdit\"") - 1) == NULL ||
        ++edit_responses != 2) {
        errno = saved_errno;
        return written;
    }

    const char message[] = "Paused after the second layout edit response\n";
    original_write(STDERR_FILENO, message, sizeof(message) - 1);
    const struct timespec poll = { .tv_nsec = 1000000 };
    unsigned int attempts = 0;
    while (access(barrier, F_OK) != 0) {
        if (++attempts == 5000) _exit(86);
        nanosleep(&poll, NULL);
    }
    // Let ingress receive didChange before the response cleanup resumes.
    const struct timespec receive = { .tv_nsec = 100000000 };
    nanosleep(&receive, NULL);
    errno = saved_errno;
    return written;
}
