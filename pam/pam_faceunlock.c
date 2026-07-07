/*
 * pam_faceunlock.c — PAM module for faceformacOS face authentication.
 *
 * Runs the faceunlock-verify helper as the authenticating user and converts
 * its exit code into a PAM result. Designed to be wired as `sufficient` so a
 * face mismatch always falls through to password authentication:
 *
 *   auth  sufficient  pam_faceunlock.so attempts=2 timeout=10
 *
 * Options (all optional):
 *   attempts=N     max face attempts per authentication, 1..5 (default 2)
 *   timeout=N      seconds per attempt, 1..60 (default 10)
 *   threshold=F    cosine-similarity threshold, 0.10..0.99 (default helper's)
 *   liveness=MODE  none | blink | turn | auto (default: auto on a tty,
 *                  blink otherwise — blink is passable without seeing prompts)
 *   helper=PATH    absolute path to faceunlock-verify
 *                  (default /usr/local/bin/faceunlock-verify)
 *   model=PATH     passed through as --model
 *   data_dir=PATH  passed through as --data-dir
 *   camera=ID      passed through as --camera
 *   quiet          suppress the informational PAM message
 *   debug          verbose syslog logging
 *
 * Exit-code mapping (see FaceUnlockExitCode in FaceUnlockCore):
 *   0 match            -> PAM_SUCCESS
 *   1 no match         -> PAM_AUTH_ERR          (falls through to password)
 *   2 not enrolled     -> PAM_IGNORE            (module is a no-op)
 *   3 camera error     -> PAM_AUTHINFO_UNAVAIL
 *   4 model missing    -> PAM_AUTHINFO_UNAVAIL
 *   other / signal     -> PAM_AUTHINFO_UNAVAIL
 *
 * Build: make -C pam   (installs as /usr/local/lib/pam/pam_faceunlock.so.2)
 */

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#include <security/pam_appl.h>
#include <security/pam_modules.h>

#ifndef PAM_EXTERN
#define PAM_EXTERN
#endif

#ifndef NSIG
#define NSIG 32
#endif

#define FU_DEFAULT_HELPER "/usr/local/bin/faceunlock-verify"
#define FU_DEFAULT_ATTEMPTS 2
#define FU_MAX_ATTEMPTS 5
#define FU_DEFAULT_TIMEOUT 10
#define FU_MAX_TIMEOUT 60
#define FU_WATCHDOG_GRACE 10 /* extra seconds before SIGKILL */

/* Exit codes shared with the Swift CLIs (FaceUnlockExitCode). */
#define FU_EXIT_MATCH 0
#define FU_EXIT_NO_MATCH 1
#define FU_EXIT_NOT_ENROLLED 2
#define FU_EXIT_CAMERA_ERROR 3
#define FU_EXIT_MODEL_MISSING 4

/* Internal child-side failure codes (outside the helper's range). */
#define FU_CHILD_EXEC_FAILED 126
#define FU_CHILD_DROP_FAILED 112
#define FU_CHILD_WRONG_USER 113

struct fu_options {
    long attempts;
    long timeout;
    const char *threshold;
    const char *liveness;
    const char *helper;
    const char *model;
    const char *data_dir;
    const char *camera;
    int quiet;
    int debug;
};

static void fu_log(int priority, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

/* Never openlog() here — that would hijack the host app's syslog identity.
 * Prefix the module name into the message instead. */
static void fu_log(int priority, const char *fmt, ...)
{
    char prefixed[512];
    va_list ap;

    snprintf(prefixed, sizeof(prefixed), "pam_faceunlock: %s", fmt);
    va_start(ap, fmt);
    vsyslog(LOG_AUTHPRIV | priority, prefixed, ap);
    va_end(ap);
}

/* Parse a bounded positive integer; returns fallback on any parse error. */
static long fu_parse_long(const char *value, long lo, long hi, long fallback)
{
    char *end = NULL;
    long parsed;

    if (value == NULL || *value == '\0')
        return fallback;
    errno = 0;
    parsed = strtol(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0')
        return fallback;
    if (parsed < lo)
        return lo;
    if (parsed > hi)
        return hi;
    return parsed;
}

static void fu_parse_options(struct fu_options *opts, int argc, const char **argv)
{
    int i;

    memset(opts, 0, sizeof(*opts));
    opts->attempts = FU_DEFAULT_ATTEMPTS;
    opts->timeout = FU_DEFAULT_TIMEOUT;
    opts->helper = FU_DEFAULT_HELPER;

    for (i = 0; i < argc; i++) {
        const char *arg = argv[i];

        if (strncmp(arg, "attempts=", 9) == 0)
            opts->attempts = fu_parse_long(arg + 9, 1, FU_MAX_ATTEMPTS, FU_DEFAULT_ATTEMPTS);
        else if (strncmp(arg, "timeout=", 8) == 0)
            opts->timeout = fu_parse_long(arg + 8, 1, FU_MAX_TIMEOUT, FU_DEFAULT_TIMEOUT);
        else if (strncmp(arg, "threshold=", 10) == 0)
            opts->threshold = arg + 10;
        else if (strncmp(arg, "liveness=", 9) == 0)
            opts->liveness = arg + 9;
        else if (strncmp(arg, "helper=", 7) == 0)
            opts->helper = arg + 7;
        else if (strncmp(arg, "model=", 6) == 0)
            opts->model = arg + 6;
        else if (strncmp(arg, "data_dir=", 9) == 0)
            opts->data_dir = arg + 9;
        else if (strncmp(arg, "camera=", 7) == 0)
            opts->camera = arg + 7;
        else if (strcmp(arg, "quiet") == 0)
            opts->quiet = 1;
        else if (strcmp(arg, "debug") == 0)
            opts->debug = 1;
        else
            fu_log(LOG_WARNING, "ignoring unknown option '%s'", arg);
    }
}

/* Send an informational message through the PAM conversation, best-effort. */
static void fu_info(pam_handle_t *pamh, const char *text)
{
    const struct pam_conv *conv = NULL;
    struct pam_message msg;
    const struct pam_message *msgp = &msg;
    struct pam_response *resp = NULL;

    if (pam_get_item(pamh, PAM_CONV, (const void **)&conv) != PAM_SUCCESS)
        return;
    if (conv == NULL || conv->conv == NULL)
        return;

    memset(&msg, 0, sizeof(msg));
    msg.msg_style = PAM_TEXT_INFO;
    msg.msg = (char *)(uintptr_t)text;

    if (conv->conv(1, &msgp, &resp, conv->appdata_ptr) == PAM_SUCCESS && resp != NULL) {
        free(resp->resp);
        free(resp);
    }
}

/*
 * The helper runs as the target user with their Keychain-encrypted enrollment,
 * so a tampered helper never executes with root privileges — but a successful
 * exit still unlocks, so require the binary itself to be root-owned and not
 * writable by group/other.
 */
static int fu_helper_is_trustworthy(const char *helper)
{
    struct stat st;

    if (helper == NULL || helper[0] != '/')
        return 0;
    if (stat(helper, &st) != 0)
        return 0;
    if (!S_ISREG(st.st_mode))
        return 0;
    if (st.st_uid != 0)
        return 0;
    if ((st.st_mode & (S_IWGRP | S_IWOTH)) != 0)
        return 0;
    return 1;
}

/* Child-side: point fd at /dev/null (open it if the fd is closed). */
static void fu_null_fd(int fd, int flags)
{
    int null_fd = open("/dev/null", flags);

    if (null_fd < 0)
        _exit(FU_CHILD_EXEC_FAILED);
    if (null_fd != fd) {
        if (dup2(null_fd, fd) < 0)
            _exit(FU_CHILD_EXEC_FAILED);
        close(null_fd);
    }
}

static void fu_child_exec(const struct fu_options *opts, const struct passwd *pw,
                          int show_prompts)
{
    char attempts_buf[16];
    char timeout_buf[16];
    const char *argv[24];
    char home_env[PATH_MAX + 8];
    char user_env[128];
    char logname_env[128];
    char *envp[6];
    int argc = 0;
    int envc = 0;
    sigset_t sigs;
    int i;

    /* Reset signal handling inherited from the PAM application. */
    for (i = 1; i < NSIG; i++)
        signal(i, SIG_DFL);
    sigemptyset(&sigs);
    sigprocmask(SIG_SETMASK, &sigs, NULL);

    /* stdin and stdout are never useful to the helper; stderr carries the
     * liveness prompts ("Blink", "Turn your head LEFT") when on a tty. */
    fu_null_fd(STDIN_FILENO, O_RDONLY);
    fu_null_fd(STDOUT_FILENO, O_WRONLY);
    if (!show_prompts)
        fu_null_fd(STDERR_FILENO, O_WRONLY);

    /* Drop privileges to the target user (PAM often runs as root for sudo). */
    if (geteuid() == 0) {
        if (initgroups(pw->pw_name, pw->pw_gid) != 0)
            _exit(FU_CHILD_DROP_FAILED);
        if (setgid(pw->pw_gid) != 0)
            _exit(FU_CHILD_DROP_FAILED);
        if (setuid(pw->pw_uid) != 0)
            _exit(FU_CHILD_DROP_FAILED);
        /* Verify the drop is irreversible. */
        if (pw->pw_uid != 0 && (setuid(0) == 0 || seteuid(0) == 0))
            _exit(FU_CHILD_DROP_FAILED);
    } else if (getuid() != pw->pw_uid) {
        /* Without root we cannot authenticate a different user. */
        _exit(FU_CHILD_WRONG_USER);
    }

    snprintf(attempts_buf, sizeof(attempts_buf), "%ld", opts->attempts);
    snprintf(timeout_buf, sizeof(timeout_buf), "%ld", opts->timeout);

    argv[argc++] = opts->helper;
    argv[argc++] = "--attempts";
    argv[argc++] = attempts_buf;
    argv[argc++] = "--timeout";
    argv[argc++] = timeout_buf;
    if (!show_prompts)
        argv[argc++] = "--quiet";
    if (opts->threshold != NULL) {
        argv[argc++] = "--threshold";
        argv[argc++] = opts->threshold;
    }
    if (opts->liveness != NULL) {
        argv[argc++] = "--liveness";
        argv[argc++] = opts->liveness;
    } else if (!show_prompts) {
        /* Without visible prompts, blinking is the only challenge a user can
         * satisfy unknowingly (people blink every few seconds anyway). */
        argv[argc++] = "--liveness";
        argv[argc++] = "blink";
    }
    if (opts->model != NULL) {
        argv[argc++] = "--model";
        argv[argc++] = opts->model;
    }
    if (opts->data_dir != NULL) {
        argv[argc++] = "--data-dir";
        argv[argc++] = opts->data_dir;
    }
    if (opts->camera != NULL) {
        argv[argc++] = "--camera";
        argv[argc++] = opts->camera;
    }
    argv[argc] = NULL;

    /* Minimal, clean environment: HOME drives the data dir + Keychain path. */
    snprintf(home_env, sizeof(home_env), "HOME=%s", pw->pw_dir);
    snprintf(user_env, sizeof(user_env), "USER=%s", pw->pw_name);
    snprintf(logname_env, sizeof(logname_env), "LOGNAME=%s", pw->pw_name);
    envp[envc++] = home_env;
    envp[envc++] = user_env;
    envp[envc++] = logname_env;
    envp[envc++] = (char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin";
    envp[envc] = NULL;

    execve(opts->helper, (char *const *)(uintptr_t)argv, envp);
    _exit(FU_CHILD_EXEC_FAILED);
}

/* Wait for the child with a hard deadline; SIGKILL + reap on overrun. */
static int fu_wait_child(pid_t child, long deadline_seconds, int *status)
{
    struct timespec poll_interval = { 0, 100 * 1000 * 1000 }; /* 100 ms */
    long waited_ms = 0;
    long deadline_ms = deadline_seconds * 1000;

    for (;;) {
        pid_t reaped = waitpid(child, status, WNOHANG);

        if (reaped == child)
            return 0;
        if (reaped < 0 && errno != EINTR)
            return -1;
        if (waited_ms >= deadline_ms) {
            kill(child, SIGKILL);
            while (waitpid(child, status, 0) < 0 && errno == EINTR)
                ;
            return 1;
        }
        nanosleep(&poll_interval, NULL);
        waited_ms += 100;
    }
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                                   int argc, const char **argv)
{
    struct fu_options opts;
    const char *user = NULL;
    struct passwd pwbuf;
    struct passwd *pw = NULL;
    char pw_storage[4096];
    pid_t child;
    int status = 0;
    int timed_out;
    int show_prompts;
    long deadline;
    char info_msg[128];

    (void)flags;

    fu_parse_options(&opts, argc, argv);

    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL || *user == '\0') {
        fu_log(LOG_NOTICE, "unable to determine the user to authenticate");
        return PAM_AUTHINFO_UNAVAIL;
    }

    if (getpwnam_r(user, &pwbuf, pw_storage, sizeof(pw_storage), &pw) != 0 || pw == NULL) {
        fu_log(LOG_NOTICE, "no passwd entry for user '%s'", user);
        return PAM_USER_UNKNOWN;
    }

    if (!fu_helper_is_trustworthy(opts.helper)) {
        fu_log(LOG_ERR,
               "helper '%s' missing or untrustworthy (must be an absolute path to a "
               "root-owned regular file not writable by group/other); skipping face auth",
               opts.helper);
        return PAM_AUTHINFO_UNAVAIL;
    }

    show_prompts = isatty(STDERR_FILENO) == 1;

    if (!opts.quiet) {
        snprintf(info_msg, sizeof(info_msg),
                 "Face unlock: look at the camera (up to %ld attempt%s, then password)",
                 opts.attempts, opts.attempts == 1 ? "" : "s");
        fu_info(pamh, info_msg);
    }

    child = fork();
    if (child < 0) {
        fu_log(LOG_ERR, "fork failed: %s", strerror(errno));
        return PAM_AUTHINFO_UNAVAIL;
    }
    if (child == 0) {
        fu_child_exec(&opts, pw, show_prompts);
        /* not reached */
        _exit(FU_CHILD_EXEC_FAILED);
    }

    deadline = opts.attempts * opts.timeout + FU_WATCHDOG_GRACE;
    timed_out = fu_wait_child(child, deadline, &status);

    if (timed_out < 0) {
        fu_log(LOG_ERR, "waitpid failed: %s", strerror(errno));
        return PAM_AUTHINFO_UNAVAIL;
    }
    if (timed_out > 0) {
        fu_log(LOG_NOTICE, "helper exceeded %lds watchdog for user '%s'; killed",
               deadline, user);
        return PAM_AUTHINFO_UNAVAIL;
    }

    if (WIFSIGNALED(status)) {
        fu_log(LOG_NOTICE, "helper terminated by signal %d for user '%s'",
               WTERMSIG(status), user);
        return PAM_AUTHINFO_UNAVAIL;
    }
    if (!WIFEXITED(status))
        return PAM_AUTHINFO_UNAVAIL;

    switch (WEXITSTATUS(status)) {
    case FU_EXIT_MATCH:
        fu_log(LOG_NOTICE, "face verified for user '%s'", user);
        return PAM_SUCCESS;
    case FU_EXIT_NO_MATCH:
        fu_log(LOG_NOTICE, "no face match for user '%s' within %ld attempt(s)",
               user, opts.attempts);
        return PAM_AUTH_ERR;
    case FU_EXIT_NOT_ENROLLED:
        if (opts.debug)
            fu_log(LOG_DEBUG, "user '%s' has no face enrollment; ignoring", user);
        return PAM_IGNORE;
    case FU_EXIT_CAMERA_ERROR:
        fu_log(LOG_NOTICE, "camera unavailable for user '%s'", user);
        return PAM_AUTHINFO_UNAVAIL;
    case FU_EXIT_MODEL_MISSING:
        fu_log(LOG_ERR, "face-embedding model missing; run the installer again");
        return PAM_AUTHINFO_UNAVAIL;
    case FU_CHILD_DROP_FAILED:
        fu_log(LOG_ERR, "failed to drop privileges to user '%s'", user);
        return PAM_AUTHINFO_UNAVAIL;
    case FU_CHILD_WRONG_USER:
        fu_log(LOG_NOTICE,
               "cannot verify user '%s' from an unprivileged context running as uid %d",
               user, (int)getuid());
        return PAM_AUTHINFO_UNAVAIL;
    case FU_CHILD_EXEC_FAILED:
        fu_log(LOG_ERR, "failed to execute helper '%s'", opts.helper);
        return PAM_AUTHINFO_UNAVAIL;
    default:
        fu_log(LOG_NOTICE, "helper exited with unexpected status %d for user '%s'",
               WEXITSTATUS(status), user);
        return PAM_AUTHINFO_UNAVAIL;
    }
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags,
                              int argc, const char **argv)
{
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}

#ifdef PAM_MODULE_ENTRY
PAM_MODULE_ENTRY("pam_faceunlock");
#endif
