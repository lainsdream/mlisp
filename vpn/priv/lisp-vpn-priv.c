/*
 * lisp-vpn-priv.c — deliberately narrow root helper for lisp-vpn on macOS.
 *
 * Install root:wheel, mode 0755. Grant sudo only for this binary, NOT for
 * setsid, route, ifconfig, or kill. No shell is ever invoked.
 *
 * Route setup/teardown is owned entirely by this helper (setup-routes /
 * teardown-routes): it captures the pre-tunnel default gateway itself,
 * persists it in a root-owned state file, and is the only thing that ever
 * reads that file back to restore it. The caller (Lisp) never sees or
 * passes a gateway address — it can't get it stale, and it can't corrupt
 * it, because it never holds it in the first place.
 */
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <limits.h>
#include <libproc.h>
#include <unistd.h>

#define ROUTE "/sbin/route"
#define IFCONFIG "/sbin/ifconfig"
#define TUN2SOCKS "/usr/local/libexec/lisp-vpn-tun2socks"
#define TUN2SOCKS_LOG "/var/log/lisp-vpn-tun2socks.log"
#define PIDFILE "/var/run/lisp-vpn-tun2socks.pid"
#define GWFILE "/var/run/lisp-vpn-original-gw"
#define TUN_IP "198.18.0.1"
#define SOCKS_URL "socks5://127.0.0.1:1080"

static void die(const char *msg) { fprintf(stderr, "lisp-vpn-priv: %s\n", msg); exit(1); }
static bool ipv4(const char *s) { struct in_addr a; return inet_pton(AF_INET, s, &a) == 1; }
static bool tun_name(const char *s) {
  if (strncmp(s, "utun", 4) != 0 || !isdigit((unsigned char)s[4])) return false;
  for (s += 5; *s; ++s) if (!isdigit((unsigned char)*s)) return false;
  return true;
}
static void exec_or_die(char *const argv[]) { execv(argv[0], argv); perror(argv[0]); _exit(127); }

/* Soft variant: run a fixed command, report success/failure, never exit
   the whole helper. Used anywhere a caller needs to try a step, keep
   going regardless, and clean up state at the end either way. */
static bool run_wait_soft(char *const argv[]) {
  pid_t p = fork(); if (p < 0) return false;
  if (p == 0) exec_or_die(argv);
  int status;
  if (waitpid(p, &status, 0) < 0) return false;
  return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
/* Hard variant: same, but a failure is fatal for the whole invocation.
   Used for one-shot commands with nothing to unwind on failure. */
static void run_wait(char *const argv[]) {
  if (!run_wait_soft(argv)) die("system command failed");
}

static void write_pid(pid_t pid) {
  int fd = open(PIDFILE, O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW, 0600);
  if (fd < 0) die("cannot create pid file");
  char buf[32]; int n = snprintf(buf, sizeof(buf), "%ld\n", (long)pid);
  if (write(fd, buf, (size_t)n) != n || fsync(fd) < 0) { close(fd); die("cannot write pid file"); }
  close(fd);
}
static pid_t read_pid(void) {
  FILE *f = fopen(PIDFILE, "r"); if (!f) return -1;
  long p = -1; int ok = fscanf(f, "%ld", &p); fclose(f);
  return ok == 1 && p > 1 && p <= INT_MAX ? (pid_t)p : -1;
}
/* A PID alone is not an identity: macOS can reuse it after a crash. */
static bool is_our_tun2socks(pid_t pid) {
  char path[PROC_PIDPATHINFO_MAXSIZE];
  int n = proc_pidpath(pid, path, sizeof(path));
  return n > 0 && strcmp(path, TUN2SOCKS) == 0;
}

/* --- gateway capture/state: the atomic-transaction piece --- */

/* Runs `route -n get default` ourselves and parses its "gateway:" line.
   No shell, no reliance on the caller's idea of what the gateway is —
   we read it straight from the kernel's routing table at the moment
   setup-routes runs, which is exactly the state we need to remember. */
static bool capture_default_gateway(char *out, size_t outlen) {
  int pipefd[2];
  if (pipe(pipefd) < 0) return false;
  pid_t p = fork();
  if (p < 0) { close(pipefd[0]); close(pipefd[1]); return false; }
  if (p == 0) {
    close(pipefd[0]);
    dup2(pipefd[1], STDOUT_FILENO);
    close(pipefd[1]);
    char *const cmd[] = { ROUTE, "-n", "get", "default", NULL };
    exec_or_die(cmd);
  }
  close(pipefd[1]);
  char buf[4096]; size_t total = 0; ssize_t n;
  while (total < sizeof(buf) - 1 &&
         (n = read(pipefd[0], buf + total, sizeof(buf) - 1 - total)) > 0)
    total += (size_t)n;
  close(pipefd[0]);
  int status;
  if (waitpid(p, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
    return false;
  buf[total] = 0;

  char *line = strstr(buf, "gateway:");
  if (!line) return false;
  line += strlen("gateway:");
  while (*line == ' ' || *line == '\t') line++;
  char gw[64]; size_t i = 0;
  while (*line && !isspace((unsigned char)*line) && i < sizeof(gw) - 1) gw[i++] = *line++;
  gw[i] = 0;
  if (!ipv4(gw) || strlen(gw) >= outlen) return false;
  strcpy(out, gw);
  return true;
}

/* O_EXCL is the whole safety property here: if a gateway is already
   captured (a previous setup-routes never got torn down — crash, reboot,
   whatever), this fails loudly instead of silently overwriting a value
   that might be the *tunnel's* gateway rather than the real one. */
static void write_gateway(const char *gw) {
  int fd = open(GWFILE, O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, 0600);
  if (fd < 0)
    die("a gateway is already captured (" GWFILE
        " exists) — run teardown-routes first, or after checking "
        "`route -n get default` by hand, remove that file yourself");
  char buf[80]; int n = snprintf(buf, sizeof(buf), "%s\n", gw);
  if (write(fd, buf, (size_t)n) != n || fsync(fd) < 0) { close(fd); die("cannot write gateway state file"); }
  close(fd);
}
static bool read_gateway(char *out, size_t outlen) {
  FILE *f = fopen(GWFILE, "r");
  if (!f) return false;
  char buf[80] = {0};
  bool ok = fscanf(f, "%79s", buf) == 1;
  fclose(f);
  if (!ok || !ipv4(buf) || strlen(buf) >= outlen) return false;
  strcpy(out, buf);
  return true;
}

int main(int argc, char **argv) {
  if (geteuid() != 0) die("must be run through sudo");
  if (argc < 2) die("missing action");

  if (!strcmp(argv[1], "start-tun")) {
    if (argc != 3 || !tun_name(argv[2])) die("usage: start-tun utunN");
    if (read_pid() > 1) die("pid file already exists; run stop-tun or remove a stale pid file after checking");
    pid_t p = fork(); if (p < 0) die("fork failed");
    if (p == 0) {
      if (setsid() < 0) _exit(127);
      /* lisp-vpn-priv's own stdout/stderr are a pipe owned by the caller
         (sudo -n lisp-vpn-priv ..., via sb-ext:run-program). That pipe
         closes the moment lisp-vpn-priv exits below, but tun2socks keeps
         running detached (setsid) long after. If tun2socks inherited that
         pipe and later wrote a log line to it, the write would fail with
         SIGPIPE and (for a Go binary) kill the whole process instantly —
         silently taking the tunnel down. Redirect to a real file first, so
         the fds it holds stay valid for as long as it runs. */
      int logfd = open(TUN2SOCKS_LOG, O_WRONLY | O_CREAT | O_APPEND, 0600);
      if (logfd >= 0) {
        dup2(logfd, STDOUT_FILENO);
        dup2(logfd, STDERR_FILENO);
        if (logfd > STDERR_FILENO) close(logfd);
      }
      char device[64]; snprintf(device, sizeof(device), "tun://%s", argv[2]);
      char *const cmd[] = { TUN2SOCKS, "-d", device, "-p", SOCKS_URL, NULL };
      exec_or_die(cmd);
    }
    write_pid(p);
    return 0;
  }
  if (!strcmp(argv[1], "stop-tun")) {
    if (argc != 2) die("usage: stop-tun");
    pid_t p = read_pid();
    if (p > 1 && kill(p, 0) == 0) {
      if (!is_our_tun2socks(p))
        die("refusing to signal PID from stale or unexpected pid file");
      if (kill(p, SIGTERM) < 0) die("failed to stop tun2socks");
    } else if (p > 1 && errno == ESRCH) {
      /* The pid file names a process that no longer exists. That doesn't
         mean there's nothing to clean up: a *different* tun2socks may be
         running under an unrecorded PID (e.g. after an interrupted
         start-tun). Warn instead of silently reporting success. */
      fprintf(stderr, "lisp-vpn-priv: warning: stale pid file (no such process %ld); "
              "check for an orphaned tun2socks manually (ps aux | grep tun2socks)\n", (long)p);
    } else if (p > 1) {
      die("cannot inspect PID from pid file");
    }
    unlink(PIDFILE); return 0;
  }
  if (!strcmp(argv[1], "assign-tun")) {
    if (argc != 3 || !tun_name(argv[2])) die("usage: assign-tun utunN");
    char *const cmd[] = { IFCONFIG, argv[2], TUN_IP, TUN_IP, "up", NULL }; run_wait(cmd); return 0;
  }

  if (!strcmp(argv[1], "setup-routes")) {
    if (argc != 3 || !ipv4(argv[2])) die("usage: setup-routes proxy-IPv4");
    char gw[64];
    if (!capture_default_gateway(gw, sizeof(gw)))
      die("could not determine current default gateway; refusing to proceed");
    /* Dies here (nothing touched yet) if a gateway is already captured. */
    write_gateway(gw);

    char *const addhost[] = { ROUTE, "-n", "add", "-host", argv[2], gw, NULL };
    if (!run_wait_soft(addhost)) {
      unlink(GWFILE);
      die("failed to add proxy host route; nothing else was changed");
    }

    char *const change[] = { ROUTE, "-n", "change", "default", TUN_IP, NULL };
    if (!run_wait_soft(change)) {
      /* Best-effort unwind: drop the host route we just added, then
         clear captured state so a retry starts clean. */
      char *const delhost[] = { ROUTE, "-n", "delete", "-host", argv[2], NULL };
      run_wait_soft(delhost);
      unlink(GWFILE);
      die("failed to set default route to tun; rolled back the proxy host route");
    }
    return 0;
  }
  if (!strcmp(argv[1], "teardown-routes")) {
    if (argc != 3 || !ipv4(argv[2])) die("usage: teardown-routes proxy-IPv4");
    char gw[64];
    bool have_gw = read_gateway(gw, sizeof(gw));
    bool restored = false;
    if (have_gw) {
      char *const change[] = { ROUTE, "-n", "change", "default", gw, NULL };
      restored = run_wait_soft(change);
    }
    /* Best-effort: the host route may already be gone (e.g. a previous
       teardown-routes partially ran). Not fatal either way. */
    char *const delhost[] = { ROUTE, "-n", "delete", "-host", argv[2], NULL };
    run_wait_soft(delhost);
    /* Unconditional: whatever happened above, don't leave stale state
       behind that would block the next setup-routes. */
    unlink(GWFILE);
    if (!have_gw)
      die("no captured original gateway found; default route was not touched (check `route -n get default` manually)");
    if (!restored)
      die("failed to restore default route to the captured gateway; state cleared, check network manually");
    return 0;
  }

  die("unknown action");
}