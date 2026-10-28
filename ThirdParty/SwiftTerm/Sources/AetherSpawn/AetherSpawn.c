#include "AetherSpawn.h"

#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>

#ifndef POSIX_SPAWN_SETEXEC
#define POSIX_SPAWN_SETEXEC 0x0040
#endif
#ifndef POSIX_SPAWN_CLOEXEC_DEFAULT
#define POSIX_SPAWN_CLOEXEC_DEFAULT 0x4000
#endif

typedef int (*setdisclaim_fn)(posix_spawnattr_t *, int);

int aether_spawn_replacing(const char *path, char *const argv[], char *const envp[])
{
    posix_spawnattr_t attrs;
    int rc = posix_spawnattr_init(&attrs);
    if (rc != 0) {
        return rc;
    }

    short flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETEXEC;
    rc = posix_spawnattr_setflags(&attrs, flags);
    if (rc != 0) {
        posix_spawnattr_destroy(&attrs);
        return rc;
    }

    setdisclaim_fn setdisclaim = (setdisclaim_fn)dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    if (setdisclaim != NULL) {
        (void)setdisclaim(&attrs, 1);
    }

    sigset_t defaults;
    sigfillset(&defaults);
    (void)posix_spawnattr_setsigdefault(&attrs, &defaults);

    sigset_t none;
    sigemptyset(&none);
    (void)posix_spawnattr_setsigmask(&attrs, &none);

    posix_spawn_file_actions_t actions;
    rc = posix_spawn_file_actions_init(&actions);
    if (rc != 0) {
        posix_spawnattr_destroy(&attrs);
        return rc;
    }

    // CLOEXEC_DEFAULT closes everything except file actions. Keep the PTY slave.
    (void)posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDIN_FILENO);
    (void)posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDOUT_FILENO);
    (void)posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDERR_FILENO);

    pid_t child = 0;
    do {
        rc = posix_spawn(&child, path, &actions, &attrs, argv, envp);
    } while (rc == EAGAIN);

    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attrs);
    return rc;
}
