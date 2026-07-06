/*
 * pam_faceunlock.c — PAM authentication module for faceformacOS.
 *
 * Execs the face-verification helper and maps its exit status onto PAM:
 *
 *     /usr/local/bin/faceunlock-verify --user <user> --timeout <N>
 *     exit 0 → PAM_SUCCESS, anything else → PAM_AUTH_ERR
 *
 * Wire it up with `sufficient` so password auth still works when the face
 * scan fails (see scripts/install.sh):
 *
 *     auth  sufficient  /usr/local/lib/pam/pam_faceunlock.so
 *
 * Module options:
 *     timeout=N          seconds to allow the helper (default 10, max 300)
 *     require_liveness   pass --require-liveness to the helper
 *     debug              syslog the helper's RESULT line and exit status
 *     quiet              never emit the PAM_TEXT_INFO "look at the camera" hint
 *
 * Security notes:
 *   - The helper path is compiled in (no path/option injection) and must be
 *     a root-owned, non-group/world-writable regular file or we refuse to run.
 *   - The child drops privileges to the target user before exec (the helper
 *     reads that user's enrollment and camera), with a minimal environment.
 *   - The helper is hard-killed a few seconds past its own timeout.
 *   - Remote (SSH) sessions are skipped — there is no camera to scan.
 */

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define PAM_SM_AUTH
#include <security/pam_appl.h>
#include <security/pam_modules.h>

#ifndef PAM_EXTERN
#define PAM_EXTERN
#endif

#define HELPER_PATH      "/usr/local/bin/faceunlock-verify"
#define DEFAULT_TIMEOUT  10
#define MAX_TIMEOUT      300
#define KILL_GRACE_SECS  5
#define OUTPUT_TAIL_MAX  512

struct module_opts {
    long timeout;
    int require_liveness;
    int debug;
    int quiet;
};

static void log_msg(int priority, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

static void log_msg(int priority, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    openlog("pam_faceunlock", LOG_PID, LOG_AUTHPRIV);
    vsyslog(priority, fmt, ap);
    closelog();
    va_end(ap);
}

static void parse_opts(struct module_opts *opts, int argc, const char **argv)
{
    int i;

    opts->timeout = DEFAULT_TIMEOUT;
    opts->require_liveness = 0;
    opts->debug = 0;
    opts->quiet = 0;

    for (i = 0; i < argc; i++) {
        if (strncmp(argv[i], "timeout=", 8) == 0) {
            char *end = NULL;
            long value = strtol(argv[i] + 8, &end, 10);
            if (end != NULL && *end == '\0' && value >= 1 && value <= MAX_TIMEOUT)
                opts->timeout = value;
            else
                log_msg(LOG_WARNING, "ignoring invalid option '%s'", argv[i]);
        } else if (strcmp(argv[i], "require_liveness") == 0) {
            opts->require_liveness = 1;
        } else if (strcmp(argv[i], "debug") == 0) {
            opts->debug = 1;
        } else if (strcmp(argv[i], "quiet") == 0) {
            opts->quiet = 1;
        } else {
            log_msg(LOG_WARNING, "ignoring unknown option '%s'", argv[i]);
        }
    }
}

/* Conservative charset gate: the name is passed as an exec argument, so in
 * particular a leading '-' must never reach the helper's flag parser. */
static int username_is_sane(const char *user)
{
    const char *p;

    if (user == NULL || *user == '\0' || *user == '-')
        return 0;
    if (strlen(user) > 255)
        return 0;
    for (p = user; *p != '\0'; p++) {
        if (!isalnum((unsigned char)*p) &&
            *p != '.' && *p != '_' && *p != '-')
            return 0;
    }
    return 1;
}

/* Refuse to exec a helper that anyone but root could have replaced. */
static int helper_is_trustworthy(const char *path)
{
    struct stat st;

    if (lstat(path, &st) != 0)
        return 0;
    if (!S_ISREG(st.st_mode))
        return 0;               /* also rejects symlinks (lstat) */
    if (st.st_uid != 0)
        return 0;
    if (st.st_mode & (S_IWGRP | S_IWOTH))
        return 0;
    return 1;
}

/* Sessions with no local camera: skip so the stack falls through cleanly. */
static int session_is_remote(pam_handle_t *pamh)
{
    const void *item = NULL;

    if (pam_get_item(pamh, PAM_RHOST, &item) == PAM_SUCCESS &&
        item != NULL && *(const char *)item != '\0')
        return 1;
    if (pam_getenv(pamh, "SSH_CONNECTION") != NULL)
        return 1;
    return 0;
}

/* Best-effort PAM_TEXT_INFO so `sudo` doesn't just sit there silently. */
static void inform(pam_handle_t *pamh, int flags,
                   const struct module_opts *opts, const char *text)
{
    const struct pam_conv *conv = NULL;
    struct pam_message msg;
    const struct pam_message *msgp;
    struct pam_response *resp = NULL;

    if (opts->quiet || (flags & PAM_SILENT))
        return;
    if (pam_get_item(pamh, PAM_CONV, (const void **)&conv) != PAM_SUCCESS ||
        conv == NULL || conv->conv == NULL)
        return;

    memset(&msg, 0, sizeof(msg));
    msg.msg_style = PAM_TEXT_INFO;
    msg.msg = (char *)text;
    msgp = &msg;

    if (conv->conv(1, &msgp, &resp, conv->appdata_ptr) == PAM_SUCCESS &&
        resp != NULL) {
        if (resp[0].resp != NULL)
            free(resp[0].resp);
        free(resp);
    }
}

/* Keep only the tail of the helper's stdout (the RESULT line is last). */
static void append_tail(char *buf, size_t cap, size_t *len,
                        const char *data, size_t n)
{
    if (n >= cap - 1) {
        memcpy(buf, data + (n - (cap - 1)), cap - 1);
        *len = cap - 1;
    } else if (*len + n > cap - 1) {
        size_t keep = (cap - 1) - n;
        memmove(buf, buf + (*len - keep), keep);
        memcpy(buf + keep, data, n);
        *len = cap - 1;
    } else {
        memcpy(buf + *len, data, n);
        *len += n;
    }
    buf[*len] = '\0';
}

static const char *last_line(char *buf)
{
    char *nl;
    size_t len = strlen(buf);

    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r'))
        buf[--len] = '\0';
    nl = strrchr(buf, '\n');
    return (nl != NULL) ? nl + 1 : buf;
}

static int run_helper(pam_handle_t *pamh, int flags,
                      const struct module_opts *opts,
                      const char *user, const struct passwd *pw)
{
    char timeout_str[16];
    char env_home[PATH_MAX + 8];
    char env_user[512];
    char env_logname[512];
    char *child_argv[8];
    char *child_envp[8];
    int argi = 0, envi = 0;
    int outpipe[2];
    pid_t pid;

    snprintf(timeout_str, sizeof(timeout_str), "%ld", opts->timeout);
    snprintf(env_home, sizeof(env_home), "HOME=%s", pw->pw_dir);
    snprintf(env_user, sizeof(env_user), "USER=%s", pw->pw_name);
    snprintf(env_logname, sizeof(env_logname), "LOGNAME=%s", pw->pw_name);

    child_argv[argi++] = (char *)"faceunlock-verify";
    child_argv[argi++] = (char *)"--user";
    child_argv[argi++] = (char *)user;
    child_argv[argi++] = (char *)"--timeout";
    child_argv[argi++] = timeout_str;
    if (opts->require_liveness)
        child_argv[argi++] = (char *)"--require-liveness";
    child_argv[argi++] = (char *)"--quiet";
    child_argv[argi] = NULL;

    child_envp[envi++] = env_home;
    child_envp[envi++] = env_user;
    child_envp[envi++] = env_logname;
    child_envp[envi++] = (char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin";
    child_envp[envi++] = (char *)"SHELL=/bin/sh";
    child_envp[envi++] = (char *)"LANG=en_US.UTF-8";
    child_envp[envi] = NULL;

    if (pipe(outpipe) != 0) {
        log_msg(LOG_ERR, "pipe() failed: %m");
        return PAM_AUTH_ERR;
    }

    inform(pamh, flags, opts, "faceunlock: look at the camera...");

    pid = fork();
    if (pid < 0) {
        log_msg(LOG_ERR, "fork() failed: %m");
        close(outpipe[0]);
        close(outpipe[1]);
        return PAM_AUTH_ERR;
    }

    if (pid == 0) {
        /* ----- child ----- */
        int devnull;
        int fd;
        int maxfd;

        /* stdio: stdin ← /dev/null, stdout → pipe, stderr → /dev/null. */
        devnull = open("/dev/null", O_RDWR);
        if (devnull < 0)
            _exit(112);
        if (dup2(devnull, STDIN_FILENO) < 0 ||
            dup2(outpipe[1], STDOUT_FILENO) < 0 ||
            dup2(devnull, STDERR_FILENO) < 0)
            _exit(113);

        /* Close everything else we may have inherited from the PAM app. */
        maxfd = (int)sysconf(_SC_OPEN_MAX);
        if (maxfd <= 0 || maxfd > 65536)
            maxfd = 65536;
        for (fd = STDERR_FILENO + 1; fd < maxfd; fd++)
            close(fd);

        /* Drop privileges to the target user. The helper must run as the
         * user: it reads their 0600 enrollment files and their camera. */
        if (geteuid() == 0) {
            if (initgroups(pw->pw_name, pw->pw_gid) != 0 ||
                setgid(pw->pw_gid) != 0 ||
                setuid(pw->pw_uid) != 0)
                _exit(114);
            if (getuid() != pw->pw_uid || geteuid() != pw->pw_uid)
                _exit(115);
        } else if (geteuid() != pw->pw_uid) {
            /* Not root and not the target user (e.g. some screensaver
             * agents): we could never read the enrollment — bail out. */
            _exit(116);
        }

        /* Never allow the helper to gain privileges back. */
        if (setuid(getuid()) != 0)
            _exit(117);

        execve(HELPER_PATH, child_argv, child_envp);
        _exit(127);
        /* ----- end child ----- */
    }

    close(outpipe[1]);
    fcntl(outpipe[0], F_SETFL, O_NONBLOCK);

    {
        char tail[OUTPUT_TAIL_MAX];
        size_t tail_len = 0;
        struct timespec deadline;
        int outfd = outpipe[0];
        int status = 0;
        int exited = 0;
        int timed_out = 0;

        tail[0] = '\0';
        clock_gettime(CLOCK_MONOTONIC, &deadline);
        deadline.tv_sec += opts->timeout + KILL_GRACE_SECS;

        while (!exited) {
            struct pollfd pfd;
            struct timespec now;
            pid_t waited;

            pfd.fd = outfd;
            pfd.events = POLLIN;
            if (poll(&pfd, 1, 200) > 0 &&
                (pfd.revents & (POLLIN | POLLHUP))) {
                char chunk[256];
                ssize_t n;
                while ((n = read(outfd, chunk, sizeof(chunk))) > 0)
                    append_tail(tail, sizeof(tail), &tail_len, chunk, (size_t)n);
                if (n == 0) {
                    close(outfd);
                    outfd = -1;   /* EOF; poll() ignores fd -1 */
                }
            }

            waited = waitpid(pid, &status, WNOHANG);
            if (waited == pid) {
                exited = 1;
                break;
            }
            if (waited < 0 && errno != EINTR) {
                log_msg(LOG_ERR, "waitpid() failed: %m");
                break;
            }

            clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec > deadline.tv_sec ||
                (now.tv_sec == deadline.tv_sec &&
                 now.tv_nsec >= deadline.tv_nsec)) {
                timed_out = 1;
                kill(pid, SIGKILL);
                waitpid(pid, &status, 0);
                break;
            }
        }

        if (outfd >= 0) {
            char chunk[256];
            ssize_t n;
            while ((n = read(outfd, chunk, sizeof(chunk))) > 0)
                append_tail(tail, sizeof(tail), &tail_len, chunk, (size_t)n);
            close(outfd);
        }

        if (timed_out) {
            log_msg(LOG_NOTICE, "helper for '%s' exceeded %lds — killed",
                    user, opts->timeout + KILL_GRACE_SECS);
            return PAM_AUTH_ERR;
        }
        if (!exited)
            return PAM_AUTH_ERR;

        if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
            if (opts->debug)
                log_msg(LOG_NOTICE, "face match for '%s' (%s)",
                        user, last_line(tail));
            return PAM_SUCCESS;
        }

        if (opts->debug) {
            if (WIFEXITED(status))
                log_msg(LOG_NOTICE, "no face match for '%s' (exit %d, %s)",
                        user, WEXITSTATUS(status), last_line(tail));
            else if (WIFSIGNALED(status))
                log_msg(LOG_NOTICE, "helper for '%s' died on signal %d",
                        user, WTERMSIG(status));
        }
        return PAM_AUTH_ERR;
    }
}

PAM_EXTERN int
pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    struct module_opts opts;
    const char *user = NULL;
    struct passwd pwbuf;
    struct passwd *pw = NULL;
    char pwstore[4096];
    char enroll_path[PATH_MAX];
    struct stat st;

    parse_opts(&opts, argc, argv);

    if (session_is_remote(pamh)) {
        if (opts.debug)
            log_msg(LOG_NOTICE, "remote session — skipping face unlock");
        return PAM_IGNORE;
    }

    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL) {
        log_msg(LOG_ERR, "unable to determine the user to authenticate");
        return PAM_AUTH_ERR;
    }
    if (!username_is_sane(user)) {
        log_msg(LOG_ERR, "refusing user name with unexpected characters");
        return PAM_AUTH_ERR;
    }

    if (getpwnam_r(user, &pwbuf, pwstore, sizeof(pwstore), &pw) != 0 ||
        pw == NULL) {
        log_msg(LOG_ERR, "no passwd entry for '%s'", user);
        return PAM_AUTH_ERR;
    }

    /* Fast path: user never enrolled → don't spin up the camera at all.
     * Only a definitive ENOENT skips; permission errors fall through to
     * the helper, which decides as the user. */
    snprintf(enroll_path, sizeof(enroll_path),
             "%s/Library/Application Support/FaceUnlock/enrollment.encrypted",
             pw->pw_dir);
    if (stat(enroll_path, &st) != 0 &&
        (errno == ENOENT || errno == ENOTDIR)) {
        if (opts.debug)
            log_msg(LOG_NOTICE, "'%s' has no face enrollment — skipping", user);
        return PAM_AUTH_ERR;
    }

    if (!helper_is_trustworthy(HELPER_PATH)) {
        log_msg(LOG_ERR,
                "%s is missing or not a root-owned, non-writable regular "
                "file — refusing to run it", HELPER_PATH);
        return PAM_AUTH_ERR;
    }

    return run_helper(pamh, flags, &opts, user, pw);
}

PAM_EXTERN int
pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}
