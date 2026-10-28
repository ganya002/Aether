#pragma once

/// Replace the current process with `path`, like execve, after disclaiming
/// TCC responsibility so the new program is not attributed to Aether.
/// Returns a posix_spawn errno; does not return on success when SETEXEC works.
int aether_spawn_replacing(const char *path, char *const argv[], char *const envp[]);
