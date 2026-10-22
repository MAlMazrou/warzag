/*
 * rosetta-watch: check that no process of an engine runs under Rosetta 2.
 *
 *   rosetta-watch <path-prefix> <stop-file> [max-seconds]
 *
 * Samples every process every 20 ms until <stop-file> exists or max-seconds (default 3600) pass. A process belongs to
 * the run when its executable path starts with <path-prefix> or its parent belongs to the run (helpers such as
 * /usr/bin/open); each is recorded once with the kernel's P_TRANSLATED flag (set while Rosetta translates it).
 * Translated processes outside the run that look like Wine ("wine" or "/Warzag.app/" in the path) are listed as
 * "foreign" for information.
 *
 * Positive control: after sampling it starts /usr/bin/arch -x86_64 /bin/sleep 1 and reads the same flag:
 * "translated" (the check works), "not_translated" (the check is blind) or "unavailable" (Rosetta is not installed).
 *
 * Prints one JSON line per process, a control line, then a summary line. Exit status: 0 when no process of the run
 * was translated and the control behaved, 3 when a process of the run was translated, 4 when the control was not
 * seen as translated although Rosetta ran it.
 *
 * Build: clang -O2 -arch arm64 -o rosetta-watch qa/n/rosetta-watch.c
 * Copyright (C) 2026 Warzag contributors. Licensed under the GNU General Public License v3.0 (see LICENSE).
 */
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

struct seen
{
    pid_t pid, ppid;
    int translated, ours;
    char path[PROC_PIDPATHINFO_MAXSIZE];
};

static struct seen seen[8192];
static int nseen;

static void json_str(const char *s)
{
    putchar('"');
    for (; *s; s++)
    {
        if (*s == '"' || *s == '\\') putchar('\\');
        if ((unsigned char)*s < 0x20) { printf("\\u%04x", *s); continue; }
        putchar(*s);
    }
    putchar('"');
}

static int is_ours(pid_t pid)
{
    for (int k = 0; k < nseen; k++)
        if (seen[k].pid == pid && seen[k].ours) return 1;
    return 0;
}

static void sample(const char *prefix)
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    struct kinfo_proc *procs;

    if (sysctl(mib, 3, NULL, &len, NULL, 0) < 0) return;
    len += 64 * sizeof(struct kinfo_proc);
    if (!(procs = malloc(len))) return;
    if (sysctl(mib, 3, procs, &len, NULL, 0) < 0) { free(procs); return; }
    for (size_t i = 0; i < len / sizeof(struct kinfo_proc); i++)
    {
        pid_t pid = procs[i].kp_proc.p_pid, ppid = procs[i].kp_eproc.e_ppid;
        int translated = (procs[i].kp_proc.p_flag & P_TRANSLATED) != 0;
        char path[PROC_PIDPATHINFO_MAXSIZE] = "";
        int k, ours, foreign;

        if (pid <= 0) continue;
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) continue;
        ours = !strncmp(path, prefix, strlen(prefix)) || (ppid > 1 && is_ours(ppid));
        foreign = !ours && translated && (strstr(path, "/Warzag.app/") || strstr(path, "wine"));
        if (!ours && !foreign) continue;
        for (k = 0; k < nseen; k++)
            if (seen[k].pid == pid && !strcmp(seen[k].path, path)) break;
        if (k < nseen) { seen[k].translated |= translated; seen[k].ours |= ours; continue; }
        if (nseen >= (int)(sizeof(seen) / sizeof(seen[0]))) continue;
        seen[nseen].pid = pid;
        seen[nseen].ppid = ppid;
        seen[nseen].translated = translated;
        seen[nseen].ours = ours;
        strlcpy(seen[nseen].path, path, sizeof(seen[nseen].path));
        nseen++;
    }
    free(procs);
}

/* The positive control: "translated", "not_translated" or "unavailable". arch normally execs the x86_64 slice in its
 * own process; a child of it is accepted too. */
static const char *control(void)
{
    char *args[] = { "/usr/bin/arch", "-x86_64", "/bin/sleep", "1", NULL };
    struct timespec pause = { 0, 5 * 1000 * 1000 };
    int status, ran_x86 = 0, translated = 0, alive = 1;
    pid_t pid;

    if (posix_spawn(&pid, args[0], NULL, NULL, args, environ)) return "unavailable";
    for (int i = 0; i < 300 && !translated && alive; i++)  /* up to 1.5 s */
    {
        int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
        struct kinfo_proc *procs;
        size_t len = 0;

        if (waitpid(pid, &status, WNOHANG) == pid) alive = 0;
        if (!sysctl(mib, 3, NULL, &len, NULL, 0) && (procs = malloc(len += 64 * sizeof(*procs))))
        {
            if (!sysctl(mib, 3, procs, &len, NULL, 0))
                for (size_t k = 0; k < len / sizeof(*procs); k++)
                {
                    pid_t p = procs[k].kp_proc.p_pid;
                    char path[PROC_PIDPATHINFO_MAXSIZE] = "";

                    if (p != pid && procs[k].kp_eproc.e_ppid != pid) continue;
                    if (proc_pidpath(p, path, sizeof(path)) <= 0 || strcmp(path, "/bin/sleep")) continue;
                    ran_x86 = 1;
                    /* flags read before the path: an exec in between is caught by the next round */
                    if (procs[k].kp_proc.p_flag & P_TRANSLATED) translated = 1;
                }
            free(procs);
        }
        if (!translated && alive) nanosleep(&pause, NULL);
    }
    if (alive)
    {
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
    }
    if (translated) return "translated";
    return ran_x86 ? "not_translated" : "unavailable";
}

int main(int argc, char **argv)
{
    struct stat st;
    double max = argc > 3 ? atof(argv[3]) : 3600;
    struct timespec start, now, pause = { 0, 20 * 1000 * 1000 };
    int ours = 0, translated = 0, foreign = 0;

    if (argc < 3)
    {
        fprintf(stderr, "usage: %s <path-prefix> <stop-file> [max-seconds]\n", argv[0]);
        return 2;
    }
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;)
    {
        sample(argv[1]);
        if (!stat(argv[2], &st)) break;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if ((now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9 > max) break;
        nanosleep(&pause, NULL);
    }
    for (int k = 0; k < nseen; k++)
    {
        printf("{\"pid\":%d,\"ppid\":%d,\"run\":%s,\"translated\":%s,\"path\":", seen[k].pid, seen[k].ppid,
               seen[k].ours ? "true" : "false", seen[k].translated ? "true" : "false");
        json_str(seen[k].path);
        printf("}\n");
        if (seen[k].ours) { ours++; translated += seen[k].translated; }
        else foreign++;
    }
    const char *ctl = control();
    printf("{\"control\":true,\"command\":\"/usr/bin/arch -x86_64 /bin/sleep 1\",\"result\":\"%s\"}\n", ctl);
    printf("{\"summary\":true,\"processes\":%d,\"translated\":%d,\"foreign_translated\":%d,\"control\":\"%s\"}\n",
           ours, translated, foreign, ctl);
    if (translated) return 3;
    return strcmp(ctl, "not_translated") ? 0 : 4;
}
