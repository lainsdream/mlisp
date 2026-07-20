/*
 * lisp-vpn-priv.c — deliberately narrow root helper for lisp-vpn on macOS.
 *
 * Install root:wheel, mode 0755. Grant sudo only for this binary, NOT for
 * setsid, route, ifconfig, or kill. No shell is ever invoked.
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
static void run_wait(char *const argv[]) {
  pid_t p = fork(); if (p < 0) die("fork failed");
  if (p == 0) exec_or_die(argv);
  int status; if (waitpid(p, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
                die("system command failed");
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
  if (!strcmp(argv[1], "add-proxy-route")) {
    if (argc != 4 || !ipv4(argv[2]) || !ipv4(argv[3])) die("usage: add-proxy-route IPv4 gateway-IPv4");
    char *const cmd[] = { ROUTE, "-n", "add", "-host", argv[2], argv[3], NULL }; run_wait(cmd); return 0;
  }
  if (!strcmp(argv[1], "remove-proxy-route")) {
    if (argc != 3 || !ipv4(argv[2])) die("usage: remove-proxy-route IPv4");
    char *const cmd[] = { ROUTE, "-n", "delete", "-host", argv[2], NULL }; run_wait(cmd); return 0;
  }
  if (!strcmp(argv[1], "enable-tun-default")) {
    if (argc != 2) die("usage: enable-tun-default");
    /* route change updates the existing route in one kernel operation. If it
       fails, the current default route remains installed. */
    char *const change[] = { ROUTE, "-n", "change", "default", TUN_IP, NULL };
    run_wait(change); return 0;
  }
  if (!strcmp(argv[1], "restore-default")) {
    if (argc != 3 || !ipv4(argv[2])) die("usage: restore-default gateway-IPv4");
    /* See enable-tun-default: do not create a no-default-route window. */
    char *const change[] = { ROUTE, "-n", "change", "default", argv[2], NULL };
    run_wait(change); return 0;
  }
  die("unknown action");
}
